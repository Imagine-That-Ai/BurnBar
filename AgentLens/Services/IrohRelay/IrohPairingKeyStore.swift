import CryptoKit
import Foundation
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import Security

/// Persists the Mac's Ed25519 pairing key. Public half is published to
/// Firestore at `users/{uid}/iroh_pairing_keys/host` by
/// `IrohPairingPublicKeyPublisher`; private half lives in the Keychain.
/// This verifier root must never rotate merely because macOS temporarily
/// denies Keychain access. Access failures therefore fail closed and leave the
/// previously published public key untouched.
final class IrohPairingKeyStore: Sendable {
    static let shared = IrohPairingKeyStore()

    private let service: String
    private let account: String
    private let keychain: any IrohPairingKeychainSecretStoring

    init(
        service: String = "ai.openburnbar.iroh-pairing",
        account: String = "primary",
        keychain: (any IrohPairingKeychainSecretStoring)? = nil
    ) {
        self.service = service
        self.account = account
        self.keychain = keychain
            ?? IrohRotatingKeychainSecretStore(service: service, account: account)
    }

    func keypair() throws -> IrohPairingKeypair {
        do {
            if let existing = try loadFromKeychain() {
                return existing
            }
        } catch IrohRotatingKeychainSecretStoreError.accessDenied(let status) {
            AppLogger.network.error(
                "iroh_pairing_keychain_access_denied_fail_closed",
                metadata: [
                    "service": service,
                    "account": account,
                    "status": "\(status)"
                ]
            )
            throw IrohPairingKeyStoreError.keychainAccessDenied(status)
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
        guard data.count == 32 else {
            throw IrohPairingKeyStoreError.invalidKey
        }
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

protocol IrohPairingKeychainSecretStoring: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

extension IrohRotatingKeychainSecretStore: IrohPairingKeychainSecretStoring {}

enum IrohPairingKeyStoreError: Error, Equatable, LocalizedError {
    case keychainAccessDenied(OSStatus)
    case keychainStatus(OSStatus)
    case invalidKey

    var errorDescription: String? {
        switch self {
        case .keychainAccessDenied(let status):
            return "OpenBurnBar could not access its Mercury pairing identity in the macOS Keychain (\(status)). Unlock this Mac and try again; the identity was not rotated."
        case .keychainStatus(let status):
            return "OpenBurnBar could not read its Mercury pairing identity from the macOS Keychain (\(status))."
        case .invalidKey:
            return "OpenBurnBar's Mercury pairing identity in the macOS Keychain is invalid. The identity was not rotated."
        }
    }
}
