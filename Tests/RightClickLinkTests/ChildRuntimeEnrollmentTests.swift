import Foundation
import XCTest
import RightClickProtocol
import RightClickLink

final class ChildRuntimeEnrollmentTests: XCTestCase {
    private struct Fixture {
        let child = try! RCIREd25519Signer(rawPrivateKey: Data(repeating: 2, count: 32))
        let parent = try! RCIREd25519Signer(rawPrivateKey: Data(repeating: 3, count: 32))
        let rogue = try! RCIREd25519Signer(rawPrivateKey: Data(repeating: 4, count: 32))
        let enrollmentID = UUID().uuidString
        let challenge = Data((0..<32).map(UInt8.init))
        let handle: EnvironmentHandle
        let manifest: EnvironmentRuntimeManifest
        init() throws {
            let rootID = UUID().uuidString
            let lineage = try EnvironmentLineage(rootEnvironmentID: rootID, parentExecutionID: UUID().uuidString,
                parentRuntimeID: RemoteNodeIdentity(signer: parent).runtimeID, depth: 0)
            handle = try .init(environmentID: rootID, providerID: "fake", providerResourceID: "fake-resource-1",
                correlationID: UUID().uuidString, lineage: lineage,
                spec: .init(profileID: "linux-small", lifetimeMilliseconds: 120_000, resources: .init()),
                createdAtMilliseconds: 1_000, expiresAtMilliseconds: 121_000)
            manifest = try .init(version: "0.2.2", executableSHA256: String(repeating: "a", count: 64), architecture: "arm64")
        }
        func claim(handle: EnvironmentHandle? = nil, manifest: EnvironmentRuntimeManifest? = nil,
                   publicKey: Data? = nil, challenge: Data? = nil, enrollmentID: String? = nil,
                   issuedAt: Int64 = 2_000, expiresAt: Int64 = 62_000) throws -> ChildRuntimeClaim {
            try .init(enrollmentID: enrollmentID ?? self.enrollmentID, handle: handle ?? self.handle,
                manifest: manifest ?? self.manifest, publicKey: publicKey ?? child.publicKey,
                challenge: challenge ?? self.challenge, issuedAtMilliseconds: issuedAt, expiresAtMilliseconds: expiresAt)
        }
        func observation(handle: EnvironmentHandle? = nil, manifest: EnvironmentRuntimeManifest? = nil,
                         publicKey: Data? = nil, runtime: Bool = true, time: Int64 = 2_200,
                         state: EnvironmentState = .ready) throws -> EnvironmentObservation {
            let selected = handle ?? self.handle
            return try .init(environmentID: selected.environmentID, correlationID: selected.correlationID,
                providerResourceID: selected.providerResourceID, presence: .present, state: state, observedAtMilliseconds: time,
                runtime: runtime ? .init(manifest: manifest ?? self.manifest, publicKey: publicKey ?? child.publicKey,
                    observedAtMilliseconds: time, observationBoundary: "Independent fake provider process/image measurement.") : nil,
                observationBoundary: "Independent fake provider resource observation; no live cloud.")
        }
        func verify(_ envelope: SignedChildRuntimeClaim? = nil, observation: EnvironmentObservation? = nil,
                    now: Int64 = 3_000) throws -> VerifiedChildRuntimeEnrollment {
            try ChildRuntimeEnrollmentVerifier.verify(signedClaim: envelope ?? .sign(claim(), using: child),
                expectedHandle: handle, expectedManifest: manifest, expectedEnrollmentID: enrollmentID,
                expectedChallenge: challenge, trustedBootstrapPublicKey: child.publicKey,
                observation: observation ?? self.observation(), now: now)
        }
        func changedHandle(environmentID: String? = nil, correlationID: String? = nil,
                           providerID: String? = nil, resource: String? = nil,
                           parentExecutionID: String? = nil, parentRuntimeID: String? = nil,
                           resources: EnvironmentResources? = nil) throws -> EnvironmentHandle {
            let id = environmentID ?? handle.environmentID
            let lineage = try EnvironmentLineage(rootEnvironmentID: id,
                parentExecutionID: parentExecutionID ?? handle.lineage.parentExecutionID,
                parentRuntimeID: parentRuntimeID ?? handle.lineage.parentRuntimeID, depth: 0)
            return try .init(environmentID: id, providerID: providerID ?? handle.providerID,
                providerResourceID: resource ?? handle.providerResourceID, correlationID: correlationID ?? handle.correlationID,
                lineage: lineage, spec: .init(profileID: handle.spec.profileID, lifetimeMilliseconds: handle.spec.lifetimeMilliseconds,
                    resources: resources ?? handle.spec.resources), createdAtMilliseconds: handle.createdAtMilliseconds,
                expiresAtMilliseconds: handle.expiresAtMilliseconds)
        }
    }

    private func assertError<T>(_ expected: ChildRuntimeEnrollmentError, _ body: @autoclosure () throws -> T,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { XCTAssertEqual($0 as? ChildRuntimeEnrollmentError, expected, file: file, line: line) }
    }

    func testValidEnrollmentUsesIndependentPinAndHostCertificate() throws {
        let f = try Fixture()
        let signed = try SignedChildRuntimeClaim.sign(f.claim(), using: f.child)
        let decoded = try SignedChildRuntimeClaim.decode(signed.wireData())
        let verified = try f.verify(decoded)
        XCTAssertEqual(verified.publicKey, f.child.publicKey)
        XCTAssertEqual(verified.runtimeID, try RemoteNodeIdentity(signer: f.child).runtimeID)
        XCTAssertEqual(verified.claimDigest, try f.claim().digest())
        let signedCertificate = try verified.certificate(using: f.parent)
        let decodedCertificate = try SignedChildRuntimeEnrollmentCertificate.decode(signedCertificate.wireData())
        let certificate = try decodedCertificate.verify(trustedPublicKey: f.parent.publicKey, now: 3_000)
        XCTAssertEqual(certificate.claim, signed.claim)
        XCTAssertEqual(try certificate.claimDigest, verified.claimDigest)
        XCTAssertEqual(certificate.runtimeObservedAtMilliseconds, 2_200)
        XCTAssertTrue(certificate.runtimeObservationBoundary.contains("fake provider"))
    }

    func testClaimSignatureProtectsEveryEnvironmentAndRuntimeBinding() throws {
        let f = try Fixture()
        let original = try SignedChildRuntimeClaim.sign(f.claim(), using: f.child)
        let mutations = try [
            f.claim(handle: f.changedHandle(environmentID: UUID().uuidString)),
            f.claim(handle: f.changedHandle(correlationID: UUID().uuidString)),
            f.claim(handle: f.changedHandle(providerID: "other-provider")),
            f.claim(handle: f.changedHandle(resource: "other-resource")),
            f.claim(handle: f.changedHandle(parentExecutionID: UUID().uuidString)),
            f.claim(handle: f.changedHandle(parentRuntimeID: RemoteNodeIdentity(signer: f.rogue).runtimeID)),
            f.claim(handle: f.changedHandle(resources: .init(cpuCount: 2))),
            f.claim(manifest: .init(version: "9.9.9", executableSHA256: f.manifest.executableSHA256, architecture: "arm64")),
            f.claim(manifest: .init(version: f.manifest.version, executableSHA256: String(repeating: "b", count: 64), architecture: "arm64")),
            f.claim(manifest: .init(version: f.manifest.version, executableSHA256: f.manifest.executableSHA256, architecture: "x86_64")),
            f.claim(challenge: Data(repeating: 8, count: 32)), f.claim(enrollmentID: UUID().uuidString),
            f.claim(issuedAt: 2_001), f.claim(expiresAt: 61_999)
        ]
        for mutated in mutations {
            let envelope = try SignedChildRuntimeClaim(claim: mutated, signature: original.signature)
            assertError(.invalidSignature, try envelope.verify(trustedPublicKey: f.child.publicKey))
        }
    }

    func testValidChildSignatureCannotOverrideExpectedRuntime() throws {
        let f = try Fixture()
        for manifest in try [
            EnvironmentRuntimeManifest(version: "9.9.9", executableSHA256: f.manifest.executableSHA256, architecture: "arm64"),
            EnvironmentRuntimeManifest(version: f.manifest.version, executableSHA256: String(repeating: "b", count: 64), architecture: "arm64"),
            EnvironmentRuntimeManifest(version: f.manifest.version, executableSHA256: f.manifest.executableSHA256, architecture: "x86_64")
        ] {
            assertError(.wrongRuntime, try f.verify(.sign(f.claim(manifest: manifest), using: f.child)))
        }
    }

    func testValidChildSignatureCannotOverrideEnvironmentOrParent() throws {
        let f = try Fixture()
        for handle in try [f.changedHandle(environmentID: UUID().uuidString), f.changedHandle(correlationID: UUID().uuidString),
                           f.changedHandle(resource: "other-resource"), f.changedHandle(providerID: "other")] {
            let error: ChildRuntimeEnrollmentError = handle.lineage == f.handle.lineage ? .wrongEnvironment : .wrongParent
            assertError(error, try f.verify(.sign(f.claim(handle: handle), using: f.child)))
        }
        assertError(.wrongParent, try f.verify(.sign(f.claim(handle: f.changedHandle(parentExecutionID: UUID().uuidString)), using: f.child)))
        assertError(.wrongParent, try f.verify(.sign(f.claim(handle: f.changedHandle(parentRuntimeID: RemoteNodeIdentity(signer: f.rogue).runtimeID)), using: f.child)))
    }

    func testRogueChildCannotPinItselfOrSignForAnotherChild() throws {
        let f = try Fixture()
        let rogueClaim = try f.claim(publicKey: f.rogue.publicKey)
        let rogueEnvelope = try SignedChildRuntimeClaim.sign(rogueClaim, using: f.rogue)
        assertError(.untrustedKey, try f.verify(rogueEnvelope))
        assertError(.untrustedKey, try SignedChildRuntimeClaim.sign(f.claim(), using: f.rogue))
        let valid = try SignedChildRuntimeClaim.sign(f.claim(), using: f.child)
        assertError(.untrustedKey, try valid.verify(trustedPublicKey: f.rogue.publicKey))
        var changedSignature = valid.signature; changedSignature[0] ^= 1
        assertError(.invalidSignature, try f.verify(.init(claim: valid.claim, signature: changedSignature)))
    }

    func testEnrollmentRequiresExactFreshIndependentRuntimeObservation() throws {
        let f = try Fixture()
        assertError(.missingObservation, try f.verify(observation: f.observation(runtime: false)))
        assertError(.missingObservation, try f.verify(observation: f.observation(state: .destroying)))
        assertError(.wrongEnvironment, try f.verify(observation: f.observation(handle: f.changedHandle(resource: "other-resource"))))
        assertError(.wrongEnvironment, try f.verify(observation: f.observation(handle: f.changedHandle(correlationID: UUID().uuidString))))
        assertError(.wrongRuntime, try f.verify(observation: f.observation(publicKey: f.rogue.publicKey)))
        let differentSHA = try EnvironmentRuntimeManifest(version: f.manifest.version, executableSHA256: String(repeating: "b", count: 64), architecture: "arm64")
        assertError(.wrongRuntime, try f.verify(observation: f.observation(manifest: differentSHA)))
        assertError(.staleObservation, try f.verify(now: 40_000))
        assertError(.staleObservation, try f.verify(observation: f.observation(time: 3_001)))
        let unknown = try EnvironmentObservation(environmentID: f.handle.environmentID, correlationID: f.handle.correlationID,
            presence: .unknown, state: .unknown, observedAtMilliseconds: 2_200, observationBoundary: "Partition; reality unknown.")
        assertError(.missingObservation, try f.verify(observation: unknown))
    }

    func testChallengeEnrollmentIdentityAndTimeAreHostPinned() throws {
        let f = try Fixture()
        assertError(.wrongChallenge, try f.verify(.sign(f.claim(challenge: Data(repeating: 9, count: 32)), using: f.child)))
        assertError(.wrongChallenge, try f.verify(.sign(f.claim(enrollmentID: UUID().uuidString), using: f.child)))
        assertError(.expired, try f.verify(now: 1_999))
        assertError(.expired, try f.verify(now: 62_000))
        assertError(.malformed, try f.claim(challenge: Data(repeating: 1, count: 31)))
        assertError(.malformed, try f.claim(expiresAt: 62_001))
    }

    func testStrictWireRejectsMalformedUnknownDuplicateOrOversizedFields() throws {
        let f = try Fixture()
        let wire = try SignedChildRuntimeClaim.sign(f.claim(), using: f.child).wireData()
        let original = String(decoding: wire, as: UTF8.self)
        let unknown = original.replacingOccurrences(of: "\"algorithm\":\"Ed25519\"", with: "\"algorithm\":\"Ed25519\",\"confirmed\":true")
        let duplicate = original.replacingOccurrences(of: "\"algorithm\":\"Ed25519\"", with: "\"algorithm\":\"Ed25519\",\"algorithm\":\"Ed25519\"")
        for text in [unknown, duplicate, original + " ", original.replacingOccurrences(of: "Ed25519", with: "none")] {
            assertError(.malformed, try SignedChildRuntimeClaim.decode(Data(text.utf8)))
        }
        assertError(.malformed, try SignedChildRuntimeClaim.decode(Data()))
        assertError(.malformed, try SignedChildRuntimeClaim.decode(Data(repeating: 123, count: 32_769)))
        assertError(.malformed, try SignedChildRuntimeClaim.decode(Data((String(repeating: "[", count: 17) + String(repeating: "]", count: 17)).utf8)))
    }

    func testCertificateTrustMutationAndExpiryFailClosed() throws {
        let f = try Fixture()
        let signed = try f.verify().certificate(using: f.parent)
        assertError(.untrustedKey, try signed.verify(trustedPublicKey: f.rogue.publicKey, now: 3_000))
        assertError(.expired, try signed.verify(trustedPublicKey: f.parent.publicKey, now: 2_999))
        assertError(.expired, try signed.verify(trustedPublicKey: f.parent.publicKey, now: 62_000))
        let altered = try ChildRuntimeEnrollmentCertificate(claim: f.claim(challenge: Data(repeating: 8, count: 32)),
            issuerPublicKey: f.parent.publicKey, environmentObservedAtMilliseconds: 2_200,
            runtimeObservedAtMilliseconds: 2_200, verifiedAtMilliseconds: 3_000,
            environmentObservationBoundary: signed.certificate.environmentObservationBoundary,
            runtimeObservationBoundary: signed.certificate.runtimeObservationBoundary)
        let forged = try SignedChildRuntimeEnrollmentCertificate(certificate: altered, signature: signed.signature)
        assertError(.invalidSignature, try forged.verify(trustedPublicKey: f.parent.publicKey, now: 3_000))
    }

    func testEphemeralNodeSignerUsesEstablishedCryptoWithoutExportingPrivateKey() throws {
        let f = try Fixture()
        let first = EphemeralChildRuntimeSigner(), second = EphemeralChildRuntimeSigner()
        XCTAssertEqual(first.publicKey.count, 32)
        XCTAssertNotEqual(first.publicKey, second.publicKey)
        let claim = try f.claim(publicKey: first.publicKey)
        let signed = try SignedChildRuntimeClaim.sign(claim, using: first)
        XCTAssertEqual(try signed.verify(trustedPublicKey: first.publicKey), claim)
    }
}
