import Foundation
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import Security

/// Persists the iroh BLOB endpoint's 32-byte secret key in the macOS
/// Keychain. Distinct from `IrohRelayKeyStore` (which holds the chat
/// endpoint's secret) so the two iroh endpoints have different NodeIds —
/// required because they advertise on different ALPNs and discovery
/// (DNS / relay) needs each NodeId to resolve to exactly one physical
/// listener at a time.
///
/// Same Keychain trust model as the chat key: generic password,
/// `WhenUnlockedThisDeviceOnly`, no iCloud sync, deleting the app removes
/// the entry.
final class IrohBlobKeyStore: @unchecked Sendable {
    static let shared = IrohBlobKeyStore()

    private let service: String
    private let account: String
    private let keychain: IrohRotatingKeychainSecretStore

    init(
        service: String = "ai.openburnbar.iroh-blob-secret",
        account: String = "primary"
    ) {
        self.service = service
        self.account = account
        self.keychain = IrohRotatingKeychainSecretStore(service: service, account: account)
    }

    func secretKeyMaterial() throws -> IrohSecretKeyMaterial {
        do {
            if let existing = try loadFromKeychain() {
                return existing
            }
        } catch IrohRotatingKeychainSecretStoreError.accessDenied(let status) {
            AppLogger.network.notice(
                "iroh_blob_keychain_access_denied_regenerating",
                metadata: [
                    "service": service,
                    "account": account,
                    "status": "\(status)"
                ]
            )
            let fresh = IrohSecretKeyMaterial.generate()
            do {
                try keychain.replace(with: fresh.raw)
            } catch {
                AppLogger.network.error(
                    "iroh_blob_keychain_ephemeral_fallback",
                    metadata: [
                        "service": service,
                        "account": account,
                        "error": error.localizedDescription
                    ]
                )
            }
            return fresh
        }
        let fresh = IrohSecretKeyMaterial.generate()
        try saveToKeychain(fresh)
        return fresh
    }

    func resetSecret() throws {
        try deleteFromKeychain()
    }

    // MARK: - Keychain plumbing

    private func loadFromKeychain() throws -> IrohSecretKeyMaterial? {
        guard let data = try keychain.load() else { return nil }
        guard data.count == 32 else { return nil }
        return IrohSecretKeyMaterial(raw: data)
    }

    private func saveToKeychain(_ secret: IrohSecretKeyMaterial) throws {
        try keychain.save(secret.raw)
    }

    private func deleteFromKeychain() throws {
        try keychain.delete()
    }
}

enum IrohBlobKeyStoreError: Error, Equatable {
    case keychainStatus(OSStatus)
}
