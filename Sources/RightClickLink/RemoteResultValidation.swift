import Foundation
import RightClickProtocol

extension RemoteExecutionSummary {
    /// Signatures authenticate the node's assertion. Consumers also require a
    /// coherent assertion before it can affect the local execution lifecycle.
    func validate() throws {
        guard completedAtMilliseconds > 0, (1...16).contains(lifecycle.count),
              Set(lifecycle).count == lifecycle.count, capabilities.count <= 128,
              Set(capabilities.map(\.id)).count == capabilities.count,
              evidenceExecutionID.map({ UUID(uuidString: $0)?.uuidString == $0 }) ?? true,
              capabilities.allSatisfy({ RemoteWire.isIdentifier($0.id) && RemoteWire.isDigest($0.contractDigest) &&
                  !$0.title.isEmpty && $0.title.utf8.count <= 512 && $0.title.rangeOfCharacter(from: .controlCharacters) == nil })
        else { throw RemoteLinkError.inconsistentResult }
        guard Array(lifecycle.prefix(3)) == [.requested, .authorized, .delivered] else { throw RemoteLinkError.inconsistentResult }
        let tail = Array(lifecycle.dropFirst(3))
        let coherentLifecycle: Bool
        if executionLifecycle != nil {
            try validatePortableLifecycle()
            coherentLifecycle = tail.first == .executing
        } else { switch state {
        case nil: coherentLifecycle = tail == [.discovered] || (error != nil && tail == [.unknown])
        case .succeeded: coherentLifecycle = tail == [.executing, .providerAccepted, .verified]
        case .accepted: coherentLifecycle = tail == [.executing, .providerAccepted, .unverified]
        case .awaitingUser: coherentLifecycle = tail == [.executing, .awaitingUser]
        case .unknown: coherentLifecycle = tail == [.unknown] || tail == [.executing, .unknown]
        case .unavailable, .unsupported, .rejected:
            coherentLifecycle = tail == [.executing, .providerRejected] || (error != nil && tail == [.unknown])
        case .failed:
            coherentLifecycle = providerAcceptance == .accepted ? tail == [.executing, .providerAccepted, .unverified] : tail == [.executing, .providerRejected]
        case .started, .cancelled: coherentLifecycle = false
        } }
        guard coherentLifecycle else { throw RemoteLinkError.inconsistentResult }
        if let runtime {
            guard runtime.version == 1, RemoteWire.isIdentifier(runtime.runtimeID), RemoteWire.isIdentifier(runtime.deviceID),
                  runtime.architecture == "arm64" || runtime.architecture == "x86_64" || runtime.architecture == "other",
                  Set(runtime.operations).isSubset(of: [.runtime, .actions, .run, .status]) else { throw RemoteLinkError.inconsistentResult }
        }
        if verification == .verifiedSuccess {
            guard state == .succeeded, providerAcceptance == .accepted, policy == .evaluated,
                  observationBoundary != .none, evidenceExecutionID != nil, error == nil,
                  (lifecycle.last == .verified || executionLifecycle?.verification == .verifiedSuccess) else { throw RemoteLinkError.inconsistentResult }
        } else if state == .succeeded { throw RemoteLinkError.inconsistentResult }
        if verification == .verifiedFailure {
            guard state == .failed, providerAcceptance == .accepted, policy == .evaluated,
                  observationBoundary != .none, evidenceExecutionID != nil else { throw RemoteLinkError.inconsistentResult }
        }
        if policy == .denied || policy == .confirmationRequired || policy == .notEvaluated {
            guard providerAcceptance == .notInvoked, verification == .unverified, observationBoundary == .none,
                  state != .succeeded && state != .accepted && state != .started else { throw RemoteLinkError.inconsistentResult }
        }
        if state == .awaitingUser, executionLifecycle?.phase != .inputRequired {
            guard policy == .confirmationRequired, lifecycle.last == .awaitingUser else { throw RemoteLinkError.inconsistentResult }
        }
        if state == .accepted {
            guard providerAcceptance == .accepted, policy == .evaluated,
                  verification == .unverified || verification == .abstained else { throw RemoteLinkError.inconsistentResult }
        }
        if state == nil {
            guard lifecycle.last == .discovered || error != nil,
                  providerAcceptance == .notInvoked else { throw RemoteLinkError.inconsistentResult }
        } else {
            guard capabilities.isEmpty, runtime == nil else { throw RemoteLinkError.inconsistentResult }
        }
        try validateEnvironmentEvidence()
    }

    /// Audit transport integrity only. The receiving parent must still pin its
    /// independent observer authority and consume causal evidence durably.
    func validateEnvironmentEvidence(trustedRuntimeKey: Data? = nil, request: RemoteExecutionRequest? = nil) throws {
        guard let audit = environmentEvidence else { return }
        do {
            guard state != nil, policy == .evaluated, evidenceExecutionID != nil,
                  try RemoteWire.encode(audit).count <= 32_768 else { throw RemoteLinkError.inconsistentResult }
            try audit.validate()
            if let enrollment = audit.runtimeEnrollment {
                // Authenticate the certificate's bytes, without trusting its
                // embedded issuer as independent approval or current authority.
                _ = try enrollment.verify(trustedPublicKey: enrollment.certificate.issuerPublicKey,
                    now: enrollment.certificate.verifiedAtMilliseconds)
            }
            guard let signed = audit.signedProof else {
                guard audit.verificationCertificate == nil else { throw RemoteLinkError.inconsistentResult }
                return
            }
            guard let enrollment = audit.runtimeEnrollment else { throw RemoteLinkError.inconsistentResult }
            let claim = enrollment.certificate.claim, proof = signed.proof, binding = proof.binding
            let pin = trustedRuntimeKey ?? signed.publicKey
            try signed.verify(trustedPublicKey: pin, using: RCIREd25519Verifier())
            guard binding.executionID == evidenceExecutionID, binding.environmentID == audit.environmentID,
                  binding.runtimeID == RemoteWire.runtimeID(pin), binding.signerID == binding.runtimeID,
                  claim.publicKey == pin, claim.runtimeID == binding.runtimeID,
                  claim.manifest.executableSHA256 == binding.executableSHA256,
                  proof.issuedAtMilliseconds >= claim.issuedAtMilliseconds,
                  proof.expiresAtMilliseconds <= claim.handle.expiresAtMilliseconds,
                  proof.observedAtMilliseconds <= completedAtMilliseconds else { throw RemoteLinkError.inconsistentResult }
            let lineage = claim.handle.lineage
            guard binding.parentEnvironmentID == lineage.parentEnvironmentID,
                  binding.parentExecutionID == (lineage.parentEnvironmentID == nil ? nil : lineage.parentExecutionID),
                  binding.parentRuntimeID == (lineage.parentEnvironmentID == nil ? nil : lineage.parentRuntimeID)
            else { throw RemoteLinkError.inconsistentResult }
            if let certificate = audit.verificationCertificate {
                try certificate.verify(trustedHostPublicKey: certificate.publicKey, using: RCIREd25519Verifier())
                let verified = certificate.verification
                guard try verified.binding.canonicalData() == binding.canonicalData(),
                      verified.proofDigest == (try proof.digest), verified.challengeNonce == proof.challengeNonce,
                      verified.sequence == proof.sequence, verified.predicateID == proof.predicateID,
                      verified.verifiedAtMilliseconds >= proof.observedAtMilliseconds,
                      verified.verifiedAtMilliseconds <= completedAtMilliseconds,
                      verified.expiresAtMilliseconds <= proof.expiresAtMilliseconds else { throw RemoteLinkError.inconsistentResult }
            }
            if let request {
                if request.operation == .run {
                    guard request.capabilityID == binding.capabilityID,
                          try EnvironmentIdentity.environmentID(from: request.item) == audit.environmentID
                    else { throw RemoteLinkError.inconsistentResult }
                } else if request.operation == .status {
                    guard request.capabilityID == binding.capabilityID, request.status?.executionID == binding.executionID
                    else { throw RemoteLinkError.inconsistentResult }
                } else { throw RemoteLinkError.inconsistentResult }
            }
        } catch let error as RemoteLinkError { throw error }
        catch { throw RemoteLinkError.inconsistentResult }
    }

    private func validatePortableLifecycle() throws {
        guard let live = executionLifecycle, live.version == 1,
              UUID(uuidString: live.executionID)?.uuidString == live.executionID,
              UUID(uuidString: live.originatingRequestID)?.uuidString == live.originatingRequestID,
              UUID(uuidString: live.taskID)?.uuidString == live.taskID,
              RemoteWire.isIdentifier(live.runtimeID), live.generation >= 0,
              live.sequence >= 0, live.sequence <= 1024,
              live.terminal == [.completed, .failed, .cancelled, .unknown].contains(live.phase),
              live.verification == verification, live.observationBoundary == observationBoundary,
              live.providerAcceptance.rawValue == providerAcceptance.rawValue,
              live.evidenceID.map({ UUID(uuidString: $0)?.uuidString == $0 }) ?? true,
              !live.receiptAvailable || live.terminal,
              !live.signedReceiptAvailable || (live.terminal && live.receiptAvailable),
              live.terminal || (live.evidenceID == nil && !live.receiptAvailable && !live.signedReceiptAvailable && result == nil),
              live.verification != .verifiedSuccess || (live.phase == .completed && live.semanticOutcome == .succeeded),
              live.semanticOutcome != .succeeded || live.verification == .verifiedSuccess,
              live.verification != .verifiedFailure || live.semanticOutcome == .failed,
              live.phase != .unknown || live.semanticOutcome == .unknown,
              live.terminal || state == .started || state == .awaitingUser,
              state != .succeeded || live.verification == .verifiedSuccess,
              live.phase != .completed || state == .accepted || state == .succeeded || state == .failed,
              live.phase != .cancelled || state == .cancelled,
              live.phase != .unknown || state == .unknown,
              live.phase != .failed || state == .failed
        else { throw RemoteLinkError.inconsistentResult }
        if let page = eventPage {
            guard page.terminal == live.terminal, page.nextCursor >= 0,
                  page.nextCursor <= live.sequence,
                  page.hasMore == (page.nextCursor < live.sequence), page.events.count <= 256
            else { throw RemoteLinkError.inconsistentResult }
            for event in page.events {
                guard event.sequence > 0, event.sequence <= live.sequence, event.time > 0,
                      ["accepted", "working", "inputRequired", "chunk", "completed", "failed", "cancelled"].contains(event.kind)
                else { throw RemoteLinkError.inconsistentResult }
                if ["completed", "failed", "cancelled"].contains(event.kind) {
                    guard live.terminal, event.sequence == live.sequence,
                          (event.kind == live.phase.rawValue || live.phase == .unknown) else { throw RemoteLinkError.inconsistentResult }
                }
            }
        }
    }

    func validatePage(after cursor: Int64, limit: Int, maximumBytes: Int) throws {
        guard let live = executionLifecycle, let page = eventPage,
              cursor >= 0, cursor <= live.sequence, page.events.count <= limit,
              page.nextCursor == cursor + Int64(page.events.count),
              page.events.enumerated().allSatisfy({ $0.element.sequence == cursor + Int64($0.offset) + 1 }),
              try page.events.reduce(0, { $0 + (try $1.canonicalData().count) }) <= maximumBytes
        else { throw RemoteLinkError.invalidSequence }
    }
}
