import Foundation
import XCTest
import RightClickProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class EnvironmentEvidenceTests: XCTestCase {
    private let execution = "00000000-0000-0000-0000-000000000001"
    private let environment = "00000000-0000-0000-0000-000000000002"
    private let parentExecution = "00000000-0000-0000-0000-000000000003"
    private let parentEnvironment = "00000000-0000-0000-0000-000000000004"
    private let consumer = "00000000-0000-0000-0000-000000000005"
    private let other = "00000000-0000-0000-0000-000000000006"
    private let nonce = Data(repeating: 7, count: 32)
    private let now: Int64 = 1_100
    private let challenge = CapabilityValue.object(["nonce": .bytes(Data(repeating: 7, count: 32)), "value": .string("external-challenge")])
    private let verifier = RCIREd25519Verifier()

    private func signer() throws -> RCIREd25519Signer {
        try RCIREd25519Signer(rawPrivateKey: Curve25519.Signing.PrivateKey().rawRepresentation)
    }

    private func binding(_ signer: RCIREd25519Signer) throws -> ExecutionProofBinding {
        try .init(executionID: execution, environmentID: environment, parentExecutionID: parentExecution,
            parentEnvironmentID: parentEnvironment, parentRuntimeID: "parent-runtime", runtimeID: "child-runtime",
            executableSHA256: String(repeating: "a", count: 64), signerID: "enrolled-child",
            keyID: ExecutionEvidenceDigest.sha256(signer.publicKey), leaseDigest: String(repeating: "b", count: 64),
            capabilityID: "environment:execute", contractDigest: String(repeating: "c", count: 64),
            requestDigest: String(repeating: "d", count: 64), responseDigest: try ExecutionEvidenceDigest.capabilityValue(challenge))
    }

    private func proof(_ signer: RCIREd25519Signer, outcome: ExecutionProofOutcome = .succeeded,
                       accepted: Bool = true, issued: Int64 = 1_000, observed: Int64 = 1_050,
                       expires: Int64 = 2_000, sequence: Int64 = 1) throws -> SignedExecutionProof {
        try .sign(.init(binding: binding(signer), challengeNonce: nonce, issuedAtMilliseconds: issued,
            observedAtMilliseconds: observed, expiresAtMilliseconds: expires, sequence: sequence,
            predicateID: "exact-challenge", providerAccepted: accepted, reportedOutcome: outcome,
            reportedValue: challenge, reportBoundary: "authenticated child assertion"), using: signer)
    }

    private func expectation(_ signer: RCIREd25519Signer, expectedNonce: Data? = nil,
                             sequence: Int64 = 1, maximumAge: Int64 = 1_000,
                             minimumIssued: Int64 = 1_000) throws -> ExecutionProofExpectation {
        try .init(binding: binding(signer), challengeNonce: expectedNonce ?? nonce, expectedSequence: sequence,
            minimumIssuedAtMilliseconds: minimumIssued, deadlineMilliseconds: 2_000,
            maximumAgeMilliseconds: maximumAge, predicateID: "exact-challenge", expectedValue: challenge)
    }

    private func adjudicate(_ proof: SignedExecutionProof, signer: RCIREd25519Signer,
                            expectation: ExecutionProofExpectation? = nil, at time: Int64? = nil,
                            observe: (ExecutionObservationRequest) throws -> CapabilityValue?) throws -> HostExecutionVerification {
        try ExecutionProofAdjudicator.adjudicate(proof, expectation: expectation ?? self.expectation(signer),
            trustedPublicKey: signer.publicKey, observerID: "parent-provider-observer",
            observationBoundary: "provider independently queried external challenge", nowMilliseconds: time ?? now,
            using: verifier, observe: observe)
    }

    private func mutate<T: Codable>(_ source: T, path: [String], value: Any) throws -> T {
        let data = try JSONEncoder().encode(source)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        func update(_ object: inout [String: Any], _ remaining: ArraySlice<String>) throws {
            let key = try XCTUnwrap(remaining.first)
            if remaining.count == 1 { object[key] = value; return }
            var child = try XCTUnwrap(object[key] as? [String: Any]); try update(&child, remaining.dropFirst()); object[key] = child
        }
        try update(&object, path[...])
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testIndependentExactExternalChallengeIsTheOnlySuccessSignal() throws {
        let child = try signer()
        for outcome in [ExecutionProofOutcome.succeeded, .accepted, .unverified, .failed, .unknown] {
            let report = try proof(child, outcome: outcome, accepted: outcome != .failed)
            var calls = 0
            let result = try adjudicate(report, signer: child) { request in
                calls += 1
                XCTAssertEqual(request.binding.executionID, self.execution)
                XCTAssertEqual(request.binding.environmentID, self.environment)
                XCTAssertEqual(request.binding.parentExecutionID, self.parentExecution)
                XCTAssertEqual(request.challengeNonce, self.nonce)
                XCTAssertEqual(request.predicateID, "exact-challenge")
                return self.challenge
            }
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(result.outcome, .succeeded)
            XCTAssertEqual(result.observedValueDigest, result.expectedValueDigest)
            XCTAssertEqual(result.proofDigest, try report.proof.digest)
        }
    }

    func testHTTPAcceptanceProcessZeroAndSignedChildSuccessWithFalseStateFail() throws {
        let child = try signer()
        let report = try proof(child, outcome: .succeeded, accepted: true)
        let actual = CapabilityValue.object(["http": .integer(200), "processExit": .integer(0),
            "childSuccess": .boolean(true), "value": .string("incorrect external challenge")])
        let result = try adjudicate(report, signer: child) { _ in actual }
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertNotEqual(result.observedValueDigest, result.expectedValueDigest)
    }

    func testMissingThrowingAndOversizedIndependentObservationsAreUnknown() throws {
        let child = try signer(); let report = try proof(child)
        XCTAssertEqual(try adjudicate(report, signer: child) { _ in nil }.outcome, .unknown)
        XCTAssertEqual(try adjudicate(report, signer: child) { _ in throw FixtureError.unavailable }.outcome, .unknown)
        let oversized = CapabilityValue.bytes(Data(repeating: 1, count: 131_073))
        let result = try adjudicate(report, signer: child) { _ in oversized }
        XCTAssertEqual(result.outcome, .unknown)
        XCTAssertNil(result.observedValueDigest)
    }

    func testValidSignatureWithEveryWrongBindingIsRejectedBeforeObservation() throws {
        let child = try signer(); let original = try proof(child)
        let mutations: [String: String] = [
            "executionID": other, "environmentID": other, "parentExecutionID": other, "parentEnvironmentID": other,
            "parentRuntimeID": "impostor-parent", "runtimeID": "impostor-child", "executableSHA256": String(repeating: "e", count: 64),
            "signerID": "impostor-signer", "leaseDigest": String(repeating: "e", count: 64),
            "capabilityID": "environment:destroy", "contractDigest": String(repeating: "e", count: 64),
            "requestDigest": String(repeating: "e", count: 64), "responseDigest": String(repeating: "e", count: 64)
        ]
        for (field, replacement) in mutations {
            let changed = try mutate(original.proof, path: ["binding", field], value: replacement)
            let signed = try SignedExecutionProof.sign(changed, using: child)
            var observed = false
            XCTAssertThrowsError(try adjudicate(signed, signer: child) { _ in observed = true; return self.challenge }) {
                XCTAssertEqual($0 as? EnvironmentEvidenceError, .bindingMismatch, field)
            }
            XCTAssertFalse(observed, field)
        }
    }

    func testWrongKeyIdentityAndUnpinnedKeyFailAuthentication() throws {
        let child = try signer(); let report = try proof(child); let stranger = try signer()
        XCTAssertThrowsError(try report.verify(trustedPublicKey: stranger.publicKey, using: verifier)) {
            XCTAssertEqual($0 as? EnvironmentEvidenceError, .untrustedKey)
        }
        let changed = try mutate(report.proof, path: ["binding", "keyID"], value: String(repeating: "f", count: 64))
        XCTAssertThrowsError(try SignedExecutionProof.sign(changed, using: child)) {
            XCTAssertEqual($0 as? EnvironmentEvidenceError, .untrustedKey)
        }
        let envelope = try SignedExecutionProof(proof: changed, signature: report.signature, publicKey: report.publicKey)
        XCTAssertThrowsError(try envelope.verify(trustedPublicKey: child.publicKey, using: verifier)) {
            XCTAssertEqual($0 as? EnvironmentEvidenceError, .untrustedKey)
        }
    }

    func testEverySignedReportFieldMutationAndForgedSignatureFail() throws {
        let child = try signer(); let report = try proof(child)
        let mutations: [(String, Any)] = [
            ("challengeNonce", Data(repeating: 8, count: 32).base64EncodedString()),
            ("issuedAtMilliseconds", 1_001), ("observedAtMilliseconds", 1_051), ("expiresAtMilliseconds", 1_999),
            ("sequence", 2), ("predicateID", "wrong-predicate"), ("providerAccepted", false),
            ("reportedOutcome", "failed"), ("reportedValue", ["string", "different report"]),
            ("reportBoundary", "changed trust boundary")
        ]
        for (field, replacement) in mutations {
            let changed = try mutate(report, path: ["proof", field], value: replacement)
            XCTAssertThrowsError(try changed.verify(trustedPublicKey: child.publicKey, using: verifier)) {
                XCTAssertEqual($0 as? EnvironmentEvidenceError, .invalidSignature, field)
            }
        }
        let forged = try SignedExecutionProof(proof: report.proof, signature: Data(repeating: 0, count: 64), publicKey: child.publicKey)
        XCTAssertThrowsError(try forged.verify(trustedPublicKey: child.publicKey, using: verifier)) {
            XCTAssertEqual($0 as? EnvironmentEvidenceError, .invalidSignature)
        }
    }

    func testStaleFutureExpiredAndOutOfWindowSignedEvidenceFail() throws {
        let child = try signer()
        let cases: [(SignedExecutionProof, ExecutionProofExpectation, Int64)] = [
            (try proof(child), try expectation(child, maximumAge: 50), now),
            (try proof(child, issued: 1_200, observed: 1_250), try expectation(child), now),
            (try proof(child, expires: 1_100), try expectation(child), now),
            (try proof(child, issued: 999), try expectation(child), now),
            (try proof(child, expires: 2_001), try expectation(child), now),
            (try proof(child), try expectation(child), 2_000)
        ]
        for (report, expected, time) in cases {
            var observed = false
            XCTAssertThrowsError(try adjudicate(report, signer: child, expectation: expected, at: time) { _ in
                observed = true; return self.challenge
            }) { XCTAssertEqual($0 as? EnvironmentEvidenceError, .invalidTime) }
            XCTAssertFalse(observed)
        }
    }

    func testReplayAndReorderingRejectAgainstAdvancedHostAdmissionPins() throws {
        let child = try signer(); let old = try proof(child)
        // Core retains the consumed sequence and next challenge in its protected journal.
        XCTAssertThrowsError(try adjudicate(old, signer: child, expectation: expectation(child, sequence: 2)) { _ in self.challenge }) {
            XCTAssertEqual($0 as? EnvironmentEvidenceError, .invalidSequence)
        }
        let next = try proof(child, sequence: 3)
        XCTAssertThrowsError(try adjudicate(next, signer: child, expectation: expectation(child, sequence: 2)) { _ in self.challenge }) {
            XCTAssertEqual($0 as? EnvironmentEvidenceError, .invalidSequence)
        }
        XCTAssertThrowsError(try adjudicate(old, signer: child,
            expectation: expectation(child, expectedNonce: Data(repeating: 9, count: 32))) { _ in self.challenge }) {
            XCTAssertEqual($0 as? EnvironmentEvidenceError, .bindingMismatch)
        }
        let wrongPredicate = try mutate(old.proof, path: ["predicateID"], value: "other-predicate")
        XCTAssertThrowsError(try adjudicate(.sign(wrongPredicate, using: child), signer: child) { _ in self.challenge }) {
            XCTAssertEqual($0 as? EnvironmentEvidenceError, .bindingMismatch)
        }
    }

    func testProofWireRoundTripCanonicalDigestAndLimits() throws {
        let child = try signer(); let report = try proof(child)
        let decoded = try SignedExecutionProof.decodeWire(report.wireData())
        XCTAssertEqual(try report.proof.canonicalData(), try decoded.proof.canonicalData())
        XCTAssertNoThrow(try decoded.verify(trustedPublicKey: child.publicKey, using: verifier))
        XCTAssertTrue(try decoded.proof.canonicalData().starts(with: Data("RIGHTCLICK-EXECUTION-PROOF-1\0".utf8)))
        XCTAssertThrowsError(try SignedExecutionProof.decodeWire(Data(repeating: 0, count: 262_145)))
        let malformed = try mutate(report, path: ["proof", "challengeNonce"], value: Data(repeating: 1, count: 31).base64EncodedString())
        XCTAssertThrowsError(try malformed.verify(trustedPublicKey: child.publicKey, using: verifier))
        let lowercaseUUID = "abcdefab-cdef-abcd-efab-cdefabcdefab"
        let invalid = try mutate(report, path: ["proof", "binding", "environmentID"], value: lowercaseUUID)
        XCTAssertThrowsError(try invalid.verify(trustedPublicKey: child.publicKey, using: verifier))
    }

    private struct DependencyFixture {
        let child: RCIREd25519Signer
        let host: RCIREd25519Signer
        let proof: SignedExecutionProof
        let certificate: SignedExecutionVerificationCertificate
        let dependency: ExecutionDependency
    }

    private func dependencyFixture(oneUse: Bool = false, observation: CapabilityValue? = nil,
                                   missingObservation: Bool = false) throws -> DependencyFixture {
        let child = try signer(); let host = try signer(); let report = try proof(child)
        let result = try adjudicate(report, signer: child) { _ in missingObservation ? nil : observation ?? self.challenge }
        let certificate = try SignedExecutionVerificationCertificate.sign(result, using: host)
        let dependency = try ExecutionDependency(executionID: execution, environmentID: environment,
            requestDigest: report.proof.binding.requestDigest, proofDigest: report.proof.digest,
            predicateID: "exact-challenge", observerID: "parent-provider-observer", maximumAgeMilliseconds: 1_000, oneUse: oneUse)
        return DependencyFixture(child: child, host: host, proof: report, certificate: certificate, dependency: dependency)
    }

    private func validate(_ fixture: DependencyFixture, dependency: ExecutionDependency? = nil,
                          certificate: SignedExecutionVerificationCertificate? = nil, omitCertificate: Bool = false,
                          consumer: String? = nil, requestDigest: String = String(repeating: "e", count: 64),
                          now: Int64 = 1_150, store: (any EnvironmentDependencyReservationStore)? = nil) throws -> ValidatedExecutionDependency {
        try ExecutionDependencyValidator.validate(dependency ?? fixture.dependency, proof: fixture.proof,
            certificate: omitCertificate ? nil : certificate ?? fixture.certificate, trustedChildPublicKey: fixture.child.publicKey,
            trustedHostPublicKey: fixture.host.publicKey, consumingExecutionID: consumer ?? self.consumer,
            consumingRequestDigest: requestDigest, nowMilliseconds: now, using: verifier, reservationStore: store)
    }

    func testCausalDependencyRequiresPinnedHostIndependentVerificationCertificate() throws {
        let fixture = try dependencyFixture()
        XCTAssertThrowsError(try validate(fixture, omitCertificate: true)) {
            XCTAssertEqual($0 as? EnvironmentEvidenceError, .independentVerificationRequired)
        }
        let result = try validate(fixture)
        XCTAssertEqual(result.proofDigest, try fixture.proof.proof.digest)
        XCTAssertEqual(result.certificateDigest, try fixture.certificate.digest)
        XCTAssertEqual(result.consumingExecutionID, consumer)
        let failed = try dependencyFixture(observation: .string("wrong external challenge"))
        XCTAssertThrowsError(try validate(failed)) { XCTAssertEqual($0 as? EnvironmentEvidenceError, .unsuccessfulDependency) }
        let unknown = try dependencyFixture(missingObservation: true)
        XCTAssertThrowsError(try validate(unknown)) { XCTAssertEqual($0 as? EnvironmentEvidenceError, .unsuccessfulDependency) }
    }

    func testWrongHostKeyChildIssuedModifiedAndForgedCertificatesFail() throws {
        let fixture = try dependencyFixture(); let stranger = try signer()
        XCTAssertThrowsError(try fixture.certificate.verify(trustedHostPublicKey: stranger.publicKey, using: verifier)) {
            XCTAssertEqual($0 as? EnvironmentEvidenceError, .untrustedKey)
        }
        let childSigned = try SignedExecutionVerificationCertificate.sign(fixture.certificate.verification, using: fixture.child)
        XCTAssertThrowsError(try validate(fixture, certificate: childSigned)) {
            XCTAssertEqual($0 as? EnvironmentEvidenceError, .untrustedKey)
        }
        let changed = try mutate(fixture.certificate, path: ["verification", "observerID"], value: "child-assertion")
        XCTAssertThrowsError(try validate(fixture, certificate: changed)) {
            XCTAssertEqual($0 as? EnvironmentEvidenceError, .invalidSignature)
        }
        let forged = try SignedExecutionVerificationCertificate(verification: fixture.certificate.verification,
            signature: Data(repeating: 0, count: 64), publicKey: fixture.host.publicKey)
        XCTAssertThrowsError(try validate(fixture, certificate: forged)) {
            XCTAssertEqual($0 as? EnvironmentEvidenceError, .invalidSignature)
        }
    }

    func testEveryDependencySelectorMismatchFailsAndFreshnessFailsClosed() throws {
        let fixture = try dependencyFixture()
        let changes: [String: String] = ["executionID": other, "environmentID": other,
            "requestDigest": String(repeating: "f", count: 64), "proofDigest": String(repeating: "f", count: 64),
            "predicateID": "wrong-predicate", "observerID": "wrong-observer"]
        for (field, value) in changes {
            let changed = try mutate(fixture.dependency, path: [field], value: value)
            XCTAssertThrowsError(try validate(fixture, dependency: changed)) {
                XCTAssertEqual($0 as? EnvironmentEvidenceError, .bindingMismatch, field)
            }
        }
        XCTAssertThrowsError(try validate(fixture, now: 1_099)) { XCTAssertEqual($0 as? EnvironmentEvidenceError, .invalidTime) }
        XCTAssertThrowsError(try validate(fixture, now: 2_000)) { XCTAssertEqual($0 as? EnvironmentEvidenceError, .invalidTime) }
        let stale = try mutate(fixture.dependency, path: ["maximumAgeMilliseconds"], value: 49)
        XCTAssertThrowsError(try validate(fixture, dependency: stale)) { XCTAssertEqual($0 as? EnvironmentEvidenceError, .invalidTime) }
        XCTAssertThrowsError(try validate(fixture, consumer: execution)) { XCTAssertEqual($0 as? EnvironmentEvidenceError, .dependencyCycle) }
    }

    func testHostCertificateMustExactlyMatchAuthenticatedChildRecord() throws {
        let fixture = try dependencyFixture()
        let changes: [(String, Any)] = [
            ("proofDigest", String(repeating: "f", count: 64)),
            ("challengeNonce", Data(repeating: 8, count: 32).base64EncodedString()),
            ("sequence", 2), ("predicateID", "wrong-predicate")
        ]
        for (field, value) in changes {
            // A correctly signed but unrelated retained host record is also rejected.
            let changed = try mutate(fixture.certificate.verification, path: [field], value: value)
            let certificate = try SignedExecutionVerificationCertificate.sign(changed, using: fixture.host)
            XCTAssertThrowsError(try validate(fixture, certificate: certificate)) {
                XCTAssertEqual($0 as? EnvironmentEvidenceError, .bindingMismatch, field)
            }
        }
        let crossEnvironment = try mutate(fixture.certificate.verification, path: ["binding", "environmentID"], value: other)
        let crossCertificate = try SignedExecutionVerificationCertificate.sign(crossEnvironment, using: fixture.host)
        XCTAssertThrowsError(try validate(fixture, certificate: crossCertificate)) {
            XCTAssertEqual($0 as? EnvironmentEvidenceError, .bindingMismatch)
        }
    }

    func testOneUseRefusesMissingStorePropagatesReservationFailureAndAllowsSameIntentRetry() throws {
        let fixture = try dependencyFixture(oneUse: true)
        XCTAssertThrowsError(try validate(fixture)) { XCTAssertEqual($0 as? EnvironmentEvidenceError, .durableReservationRequired) }
        let store = ReservationFixture()
        let first = try validate(fixture, store: store)
        let retry = try validate(fixture, store: store)
        XCTAssertEqual(first.certificateDigest, retry.certificateDigest)
        XCTAssertEqual(store.reservations.count, 1)
        XCTAssertThrowsError(try validate(fixture, consumer: other, store: store)) {
            XCTAssertEqual($0 as? FixtureError, .consumed)
        }
        XCTAssertThrowsError(try validate(fixture, requestDigest: String(repeating: "f", count: 64), store: store)) {
            XCTAssertEqual($0 as? FixtureError, .consumed)
        }
        let unavailable = ReservationFixture(); unavailable.fail = true
        XCTAssertThrowsError(try validate(fixture, store: unavailable)) { XCTAssertEqual($0 as? FixtureError, .unavailable) }
        XCTAssertTrue(unavailable.reservations.isEmpty)
    }

    func testCertificateWireRoundTripAndDomainSeparation() throws {
        let fixture = try dependencyFixture()
        let decoded = try SignedExecutionVerificationCertificate.decodeWire(fixture.certificate.wireData())
        XCTAssertEqual(try decoded.digest, try fixture.certificate.digest)
        XCTAssertNoThrow(try decoded.verify(trustedHostPublicKey: fixture.host.publicKey, using: verifier))
        XCTAssertTrue(try decoded.verification.canonicalData().starts(with: Data("RIGHTCLICK-HOST-EXECUTION-VERIFICATION-1\0".utf8)))
        XCTAssertThrowsError(try SignedExecutionVerificationCertificate.decodeWire(Data(repeating: 0, count: 262_145)))
        XCTAssertFalse(try verifier.verify(signature: fixture.proof.signature,
            payload: decoded.verification.canonicalData(), publicKey: fixture.child.publicKey))
    }

    private enum FixtureError: Error, Equatable { case unavailable, consumed }
    /// Exercises the injection contract only; Core tests must prove disk durability.
    private final class ReservationFixture: EnvironmentDependencyReservationStore {
        var reservations: [String: (String, String, String)] = [:]
        var fail = false
        func reserve(dependencyProofDigest: String, certificateDigest: String,
                     consumingExecutionID: String, consumingRequestDigest: String) throws {
            guard !fail else { throw FixtureError.unavailable }
            if let old = reservations[dependencyProofDigest] {
                guard old.0 == certificateDigest, old.1 == consumingExecutionID, old.2 == consumingRequestDigest else {
                    throw FixtureError.consumed
                }
                return
            }
            reservations[dependencyProofDigest] = (certificateDigest, consumingExecutionID, consumingRequestDigest)
        }
    }
}
