// Cross-language interop fixture generator. Reproduces the exact wire format of
// OpenBurnBarCore/.../CloudVaultCrypto.swift (HKDF info "OpenBurnBar-Escrow-v1",
// x963 ephemeral pubkey ‖ AES-GCM .combined) so the JS escrow lib can prove it
// opens Swift-sealed content and unwraps a Swift-wrapped vault key.
//
// Usage: swift seal.swift  -> prints a JSON fixture to stdout.
import CryptoKit
import Foundation

func b64(_ d: Data) -> String { d.base64EncodedString() }

let vaultKey = SymmetricKey(size: .bits256)
let vaultKeyData = vaultKey.withUnsafeBytes { Data($0) }

// 1) Seal a blob exactly like CloudVaultCrypto.sealBlob (.combined = nonce‖ct‖tag).
let plaintext = "Swift sealed this for the browser".data(using: .utf8)!
let sealed = try! AES.GCM.seal(plaintext, using: vaultKey)
let blobCombined = sealed.combined!
let plaintextSHA = SHA256.hash(data: plaintext).map { String(format: "%02x", $0) }.joined()

// 2) Seal text like CloudVaultCrypto.sealText (separate nonce/ciphertext/tag).
let textPlain = "conversation body from swift".data(using: .utf8)!
let sealedText = try! AES.GCM.seal(textPlain, using: vaultKey)
let nonceData = sealedText.nonce.withUnsafeBytes { Data($0) }

// 3) Recipient (the browser's device key) — generated here as JS will import it.
let recipientPriv = P256.KeyAgreement.PrivateKey()
let recipientPubX963 = recipientPriv.publicKey.x963Representation
let recipientPrivPKCS8 = recipientPriv.derRepresentation // PKCS#8 DER, importable by WebCrypto

// 4) Wrap the vault key for the recipient, exactly like CloudVaultCrypto.wrapVaultKey.
let ephemeral = P256.KeyAgreement.PrivateKey()
let shared = try! ephemeral.sharedSecretFromKeyAgreement(with: recipientPriv.publicKey)
let wrappingKey = shared.hkdfDerivedSymmetricKey(
    using: SHA256.self,
    salt: Data(),
    sharedInfo: Data("OpenBurnBar-Escrow-v1".utf8),
    outputByteCount: 32
)
let wrappedSealed = try! AES.GCM.seal(vaultKeyData, using: wrappingKey)
let wrapped = ephemeral.publicKey.x963Representation + wrappedSealed.combined!

let fixture: [String: Any] = [
    "vaultKeyB64": b64(vaultKeyData),
    "blob": [
        "schemaVersion": 1,
        "algorithm": "AES-256-GCM",
        "keyVersion": 1,
        "plaintextSHA256": plaintextSHA,
        "sealedBoxBase64": b64(blobCombined),
        "createdAt": ISO8601DateFormatter().string(from: Date()),
        "expectedPlaintext": "Swift sealed this for the browser",
    ],
    "text": [
        "algorithm": "AES-256-GCM",
        "keyVersion": 1,
        "nonce": b64(nonceData),
        "ciphertext": b64(sealedText.ciphertext),
        "tag": b64(sealedText.tag),
        "expectedPlaintext": "conversation body from swift",
    ],
    "recipientPrivatePKCS8B64": b64(recipientPrivPKCS8),
    "recipientPublicX963B64": b64(recipientPubX963),
    "wrappedVaultKeyB64": b64(wrapped),
]

let json = try! JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted])
FileHandle.standardOutput.write(json)
