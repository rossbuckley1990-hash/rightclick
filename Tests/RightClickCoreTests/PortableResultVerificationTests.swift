import Foundation
import XCTest
@testable import RightClickCore

final class PortableResultVerificationTests: XCTestCase {
    private final class OrdinaryReflector: CapabilityReflector {
        let id = "fixture:ordinary-observation-boundary"
        let removeInputFile: Bool
        var starts = 0
        init(removeInputFile: Bool = false) { self.removeInputFile = removeInputFile }
        func capabilities(for item: ContentItem) throws -> [Capability] {
            [.init(id: "fixture:ordinary-result", title: "Ordinary portable result", source: .system,
                reflectorID: id, safety: .localReversible, invocation: .direct,
                supportLevel: .publicSupported, requiresConfirmation: false)]
        }
        func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
            starts += 1
            if removeInputFile, let path = item.path { try FileManager.default.removeItem(atPath: path) }
            return .init(executionId: executionID, actionId: capability.id, state: .accepted,
                message: "The provider accepted the invocation.", output: "requested",
                result: .object(["value": .string("requested")]),
                evidence: .init(type: "provider_acceptance", boundary: "No semantic observation from provider acceptance.",
                    outcomeVerified: false, observationBoundary: OutcomeObservationBoundary.none))
        }
    }

    func testOrdinaryReturnedPredicatesPreserveReturnedValueObservationBoundary() throws {
        for type in [VerificationPredicateType.textEquals, .resultPathEquals] {
            for matches in [true, false] {
                let reflector = OrdinaryReflector(), engine = CapabilityEngine(reflectors: [reflector], experience: nil)
                let specification = VerificationSpec(predicates: [.init(type: type,
                    key: type == .resultPathEquals ? "value" : nil, value: matches ? "requested" : "different")])
                let record = try engine.begin(id: "fixture:ordinary-result", item: "portable returned predicate",
                    confirmed: true, verification: specification)
                XCTAssertEqual(reflector.starts, 1)
                XCTAssertEqual(record.state, matches ? .succeeded : .failed)
                XCTAssertEqual(record.verification?.status, matches ? .verifiedSuccess : .verifiedFailure)
                XCTAssertEqual(record.evidence.observationBoundary, .returnedValue,
                    "Returned bytes cannot claim independent external-state observation")
                XCTAssertEqual(record.evidence.outcomeVerified, matches)
                XCTAssertNil(record.rcir, "This fixture must exercise ordinary Core verification")
                XCTAssertNil(record.lifecycle)
            }
        }
    }

    func testOrdinaryFilePredicatesPreserveExternalStateObservationBoundary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ordinary-file-observer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for existsAfter in [true, false] {
            let file = directory.appendingPathComponent(UUID().uuidString + ".txt")
            try Data("observed file".utf8).write(to: file)
            let reflector = OrdinaryReflector(removeInputFile: !existsAfter)
            let engine = CapabilityEngine(reflectors: [reflector], experience: nil)
            let record = try engine.begin(id: "fixture:ordinary-result", item: file.path, confirmed: true,
                verification: .init(predicates: [.init(type: .fileExists)]))
            XCTAssertEqual(reflector.starts, 1)
            XCTAssertEqual(record.state, existsAfter ? .succeeded : .failed)
            XCTAssertEqual(record.verification?.status, existsAfter ? .verifiedSuccess : .verifiedFailure)
            XCTAssertEqual(record.evidence.observationBoundary, .externalState,
                "Filesystem postconditions observe external state rather than provider-returned bytes")
            XCTAssertEqual(record.evidence.outcomeVerified, existsAfter)
            XCTAssertNil(record.rcir)
            XCTAssertNil(record.lifecycle)
        }
    }

    func testOrdinaryProviderAcceptanceAloneRemainsUnverified() throws {
        let reflector = OrdinaryReflector(), engine = CapabilityEngine(reflectors: [reflector], experience: nil)
        let record = try engine.begin(id: "fixture:ordinary-result", item: "portable acceptance", confirmed: true)
        XCTAssertEqual(reflector.starts, 1)
        XCTAssertEqual(record.state, .accepted)
        XCTAssertNil(record.verification)
        XCTAssertFalse(record.evidence.outcomeVerified)
        XCTAssertEqual(record.evidence.observationBoundary, OutcomeObservationBoundary.none)
        XCTAssertNil(record.rcir)
        XCTAssertNil(record.lifecycle)
    }

    private func verifyReturnedResult(
        _ returnedResult: CapabilityValue?,
        expected: String
    ) throws -> OutcomeVerification {
        let item = ContentItem(
            kind: "text",
            display: "typed-result-fixture",
            text: "typed-result-fixture",
            typeIdentifier: "public.plain-text"
        )

        let before = try OutcomeVerifier.snapshot(
            item: item
        )

        return try OutcomeVerifier.verify(
            spec: VerificationSpec(
                predicates: [
                    VerificationPredicate(
                        type: .resultPathEquals,
                        key: "value",
                        value: expected
                    )
                ]
            ),
            item: item,
            before: before,
            returnedText: nil,
            returnedResult: returnedResult
        )
    }

    func testResultPathEqualsVerifiesExactReturnedString() throws {
        let verification = try verifyReturnedResult(
            .object([
                "value": .string("requested")
            ]),
            expected: "requested"
        )

        XCTAssertEqual(
            verification.status,
            .verifiedSuccess
        )

        XCTAssertEqual(
            verification.predicates.first?.evaluated,
            true
        )

        XCTAssertEqual(
            verification.predicates.first?.passed,
            true
        )

        XCTAssertEqual(
            verification.predicates.first?.actual,
            "requested"
        )
    }

    func testResultPathEqualsDetectsReturnedStringMismatch() throws {
        let verification = try verifyReturnedResult(
            .object([
                "value": .string("different")
            ]),
            expected: "requested"
        )

        XCTAssertEqual(
            verification.status,
            .verifiedFailure
        )

        XCTAssertEqual(
            verification.predicates.first?.evaluated,
            true
        )

        XCTAssertEqual(
            verification.predicates.first?.passed,
            false
        )

        XCTAssertEqual(
            verification.predicates.first?.actual,
            "different"
        )
    }

    func testResultPathEqualsMissingPathRemainsUnverified() throws {
        let verification = try verifyReturnedResult(
            .object([
                "other": .string("requested")
            ]),
            expected: "requested"
        )

        XCTAssertEqual(
            verification.status,
            .unverified
        )

        XCTAssertEqual(
            verification.predicates.first?.evaluated,
            false
        )

        XCTAssertEqual(
            verification.predicates.first?.passed,
            false
        )

        XCTAssertNil(
            verification.predicates.first?.actual
        )
    }
}
