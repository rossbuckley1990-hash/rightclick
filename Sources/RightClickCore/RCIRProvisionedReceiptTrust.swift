import Foundation

/// Protected, host-owned receipt policy around the existing trust primitive.
/// Retained reconciliation prevents an older source from resurrecting a revoked
/// key in this running host. It is not restart/distributed revocation storage.
final class RCIRProvisionedReceiptTrust {
    private let reference: String
    private let currentReference: () -> String?
    private let policy: RCIRReceiptTrustPolicy
    private let lock = NSLock()

    init(path: String, currentReference: @escaping () -> String?,
         clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) throws {
        let document = try Self.load(path: path, currentReference: currentReference)
        policy = try .init(issuerID: document.issuerID, records: document.records,
                           maximumLiveAge: document.maximumLiveAge, clock: clock)
        reference = path; self.currentReference = currentReference
    }

    /// Refresh from protected host input even when the private signing key is
    /// unchanged. The returned token is minted only by the retained policy.
    func authorization(for publicKey: Data) throws -> RCIRReceiptSigningAuthorization {
        lock.lock(); defer { lock.unlock() }
        try refresh()
        return try policy.authorization(for: publicKey)
    }

    func revalidate(_ token: RCIRReceiptSigningAuthorization) throws {
        lock.lock(); defer { lock.unlock() }
        try refresh()
        try policy.revalidate(token)
    }

    private func refresh() throws {
        let document = try Self.load(path: reference, currentReference: currentReference)
        try policy.reconcile(issuerID: document.issuerID, records: document.records,
                             maximumLiveAge: document.maximumLiveAge)
    }

    private static func load(path: String, currentReference: () -> String?) throws -> RCIRReceiptTrustDocument {
        func current() -> Bool { currentReference()?.utf8.elementsEqual(path.utf8) == true }
        guard current() else { throw RCIRError.authorityDenied }
        let snapshot: CapabilityArtifactSnapshot
        let data: Data
        do {
            snapshot = try .init(source: URL(fileURLWithPath: path), maximum: RCIRReceiptTrustDocument.maximumBytes, protected: true)
            data = try CapabilityArtifactSnapshot.read(source: snapshot.file, maximum: RCIRReceiptTrustDocument.maximumBytes, protected: true)
        } catch { throw RCIRError.authorityDenied }
        let document = try RCIRReceiptTrustDocument.read(data)
        guard current(), snapshot.sourceStillMatches() else { throw RCIRError.authorityDenied }
        return document
    }
}
