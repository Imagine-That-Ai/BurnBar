import Foundation
import OpenBurnBarComputerUseCore

/// Loads the active Remote Unlock presenter binding from the signed local
/// context ledger. The privileged input leaf uses this as trusted context and
/// ignores caller-supplied binding fields in the dispatch envelope.
public struct RemoteUnlockSessionContextFileProvider: Sendable {
    private let store: RemoteUnlockSessionContextSnapshotStore
    private let now: @Sendable () -> Date
    private let issuerTrustProvider: @Sendable () -> CapabilityTokenIssuerTrust?

    public init(
        path: String = RemoteUnlockSetupProbe.sessionContextSnapshotLedgerPath,
        now: @escaping @Sendable () -> Date = Date.init,
        issuerTrustProvider: @escaping @Sendable () -> CapabilityTokenIssuerTrust? = {
            try? CapabilityTokenIssuerTrustMaterial.load()?.issuerTrust()
        }
    ) {
        self.store = RemoteUnlockSessionContextSnapshotStore(path: path)
        self.now = now
        self.issuerTrustProvider = issuerTrustProvider
    }

    public func context(for token: CapabilityToken?) -> RemoteUnlockSessionContext {
        guard let token,
              let snapshot = try? store.loadVerified(
                  scopeHash: token.scopeHash,
                  now: now(),
                  issuerTrust: issuerTrustProvider()
              ) else {
            return .none
        }
        return RemoteUnlockSessionContext(
            escrowDeviceId: snapshot.escrowDeviceId,
            attestationHashBlake3: snapshot.attestationHashBlake3,
            scopeHash: snapshot.scopeHash
        )
    }
}
