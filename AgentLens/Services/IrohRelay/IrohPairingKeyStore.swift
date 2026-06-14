import CryptoKit
import Foundation
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import Security

/// Persists the Mac's Ed25519 pairing key. Public half is published to
/// Firestore at `users/{uid}/iroh_pairing_keys/host` by
/// `IrohPairingPublicKeyPublisher`; private half lives in the Keychain.
/// Normal operation keeps this stable. If macOS denies access to a stale
/// Keychain ACL item from an older/dev-signed build, the host regenerates and
/// republishes the verifier key so iOS does not get stuck behind a prompt.
final class IrohPairingKeyStore: Sendable {
    static let shared = IrohPairingKeyStore()

    private let service: String
    private let account: String
    private let keychain: IrohRotatingKeychainSecretStore

    init(
        service: String = "ai.openburnbar.iroh-pairing",
        account: String = "primary"
    ) {
        self.service = service
        self.account = account
        self.keychain = IrohRotatingKeychainSecretStore(service: service, account: account)
    }

    func keypair() throws -> IrohPairingKeypair {
        do {
            if let existing = try loadFromKeychain() {
                return existing
            }
        } catch IrohRotatingKeychainSecretStoreError.accessDenied(let status) {
            AppLogger.network.notice(
                "iroh_pairing_keychain_access_denied_regenerating",
                metadata: [
                    "service": service,
                    "account": account,
                    "status": "\(status)"
                ]
            )
            let fresh = IrohPairingKeypair()
            do {
                try keychain.replace(with: fresh.signingKey.rawRepresentation)
            } catch {
                AppLogger.network.error(
                    "iroh_pairing_keychain_ephemeral_fallback",
                    metadata: [
                        "service": service,
                        "account": account,
                        "errorClass": "\(String(describing: type(of: error)))"
                    ]
                )
            }
            return fresh
        }
        let fresh = IrohPairingKeypair()
        try saveToKeychain(fresh)
        return fresh
    }

    var publicKeyBase64: String? {
        // The pairing public key is published for verifier pinning; a
        // load/generate failure should be observable, not silently collapse
        // the host into a keyless "unpaired" state.
        AppLogger.network.silently(
            "iroh_pairing_public_key_unavailable",
            try keypair().publicKeyBase64 as String?,
            fallback: nil
        )
    }

    // MARK: - Keychain plumbing

    private func loadFromKeychain() throws -> IrohPairingKeypair? {
        guard let data = try keychain.load() else { return nil }
        guard data.count == 32 else { return nil }
        do {
            let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
            return IrohPairingKeypair(signingKey: signingKey)
        } catch {
            throw IrohPairingKeyStoreError.invalidKey
        }
    }

    private func saveToKeychain(_ keypair: IrohPairingKeypair) throws {
        try keychain.save(keypair.signingKey.rawRepresentation)
    }
}

enum IrohPairingKeyStoreError: Error, Equatable {
    case keychainStatus(OSStatus)
    case invalidKey
}
