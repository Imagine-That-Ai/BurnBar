import FirebaseAuth
import FirebaseCore
import Foundation
import OpenBurnBarComputerUseCore
import os

enum MobileAppCheckAttestationReader {
    /// Last digest produced by `currentAttestationDigestForEnvelope()`. Kept so
    /// the synchronous `sign(remoteUnlockSession:)` path can attach the digest
    /// (pre-F2 it omitted the field entirely); every async send refreshes it.
    private static let cachedDigest = OSAllocatedUnfairLock<String?>(initialState: nil)

    static func currentAttestationDigestForEnvelope() async -> String? {
        guard FirebaseApp.app() != nil else { return nil }
        guard let user = Auth.auth().currentUser, !user.isAnonymous else { return nil }
        do {
            let result = try await user.getIDTokenResult(forcingRefresh: false)
            guard let claim = AppCheckAttestationBinding.parseClaim(from: result.claims as? [String: Any]),
                  AppCheckAttestationBinding.isFresh(claim) else {
                return nil
            }
            let digest = AppCheckAttestationBinding.digestHex(for: claim)
            cachedDigest.withLock { $0 = digest }
            return digest
        } catch {
            return nil
        }
    }

    /// Synchronous best-effort digest for envelope builders that cannot await
    /// (remote-unlock session signing). `nil` until an async read has run —
    /// identical wire shape to the pre-F2 always-absent behavior.
    static func cachedAttestationDigestForEnvelope() -> String? {
        cachedDigest.withLock { $0 }
    }
}
